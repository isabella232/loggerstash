require 'logstash_writer'
require 'thread'

# A sidecar class to augment a Logger with super-cow-logstash-forwarding
# powers.
#
class Loggerstash
  # Base class of all Loggerstash errors
  #
  class Error < StandardError; end

  # Raised if any configuration setter methods are called (`Loggerstash#<anything>=`)
  # after the loggerstash instance has been attached to a logger.
  #
  class AlreadyRunningError < Error; end

  # Set the formatter proc to a new proc.
  #
  # The passed in proc must take four arguments: `severity`, `timestamp`,
  # `progname` and `message`.  `timestamp` is a `Time`, all over arguments
  # are `String`s, and `progname` can possibly be `nil`.  It must return a
  # Hash containing the parameters you wish to send to logstash.
  #
  attr_writer :formatter

  # A new Loggerstash!
  #
  # @param logstash_server [String] an address:port, hostname:port, or srvname
  #   to which a `json_lines` logstash connection can be made.
  # @param metrics_registry [Prometheus::Client::Registry] where the metrics
  #   which are used by the underlying `LogstashWriter` should be registered,
  #   for later presentation by the Prometheus client.
  # @param formatter [Proc] a formatting proc which takes the same arguments
  #   as the standard `Logger` formatter, but rather than emitting a string,
  #   it should pass back a Hash containing all the fields you wish to send
  #   to logstash.
  #
  def initialize(logstash_server:, metrics_registry: nil, formatter: nil)
    @logstash_server = logstash_server
    @metrics_registry = metrics_registry
    @formatter = formatter

    @op_mutex = Mutex.new
  end

  # Associate this Loggerstash with a Logger (or class of Loggers).
  #
  # A single Loggerstash instance can be associated with one or more Logger
  # objects, or all instances of Logger, by attaching the Loggerstash to the
  # other object (or class).  Attaching a Loggerstash means it can no longer
  # be configured (by the setter methods).
  #
  # @param obj [Object] the instance or class to attach this Loggerstash to.
  #   We won't check that you're attaching to an object or class that will
  #   benefit from the attachment; that's up to you to ensure.
  #
  def attach(obj)
    @op_mutex.synchronize do
      obj.instance_variable_set(:@loggerstash, self)

      if obj.is_a?(Module)
        obj.prepend(Mixin)
      else
        obj.singleton_class.prepend(Mixin)
      end

      run_writer
    end
  end

  %i{logstash_server metrics_registry}.each do |sym|
    define_method(:"#{sym}=") do |v|
      @op_mutex.synchronize do
        if @logstash_writer
          raise AlreadyRunningError,
                "Cannot change #{sym} once writer is running"
        end
        instance_variable_set(:"@#{sym}", v)
      end
    end
  end

  # Send a logger message to logstash.
  #
  # @private
  #
  def log_message(s, t, p, m)
    @op_mutex.synchronize do
      if @logstash_writer.nil?
        #:nocov:
        run_writer
        #:nocov:
      end

      @logstash_writer.send_event((@formatter || default_formatter).call(s, t, p, m))
    end
  end

  private

  # Do the needful to get the writer going.
  #
  # This will error out unless the @op_mutex is held at the time the
  # method is called; we can't acquire it ourselves because some calls
  # to run_writer already need to hold the mutex.
  #
  def run_writer
    unless @op_mutex.owned?
      #:nocov:
      raise RuntimeError,
            "Must call run_writer while holding @op_mutex"
      #:nocov:
    end

    if @logstash_writer.nil?
      {}.tap do |opts|
        opts[:server_name] = @logstash_server
        if @metrics_registry
          opts[:metrics_registry] = @metrics_registry
        end

        @logstash_writer = LogstashWriter.new(**opts)
        @logstash_writer.run
      end
    end
  end

  # Mangle the standard sev/time/prog/msg set into a minimal logstash
  # event.
  #
  def default_formatter
    @default_formatter ||= ->(s, t, p, m) do
      {
        "@timestamp" => t.utc.strftime("%FT%T.%NZ"),
        message: m,
        severity: s.downcase,
      }.tap do |ev|
        ev[:progname] = p if p
      end
    end
  end

  # The methods needed to turn any Logger into a Loggerstash Logger.
  #
  module Mixin
    private

    # Hooking into this specific method may seem... unorthodox, but
    # it seemingly has an extremely stable interface and is the most
    # appropriate place to inject ourselves.
    def format_message(s, t, p, m)
      loggerstash.log_message(s, t, p, m)

      super
    end

    # Find where our associated Loggerstash object is being held captive.
    #
    # We're kinda reimplementing Ruby's method lookup logic here, but there's
    # no other way to store our object *somewhere* in the object + class
    # hierarchy and still be able to get at it from a module (class variables
    # don't like being accessed from modules).
    #
    def loggerstash
      ([self] + self.class.ancestors).find { |m| m.instance_variable_defined?(:@loggerstash) }.instance_variable_get(:@loggerstash).tap do |ls|
        if ls.nil?
          #:nocov:
          raise RuntimeError,
                "Cannot find loggerstash instance.  CAN'T HAPPEN."
          #:nocov:
        end
      end
    end
  end
end