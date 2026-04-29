# frozen_string_literal: true

require "abstract_unit"

class CacheExpiryViewReloaderTest < ActiveSupport::TestCase
  # A no-op watcher class with the FileUpdateChecker API. Used instead of the
  # real ActiveSupport::FileUpdateChecker so we can assert exactly when the
  # watcher is materialized — its #initialize bumps a counter we can read.
  class CountingWatcher
    @@built = 0

    class << self
      def reset!
        @@built = 0
      end

      def built
        @@built
      end
    end

    def initialize(_files, _dirs = {}, &block)
      @block = block
      @@built += 1
    end

    def updated?
      false
    end

    def execute
      @block&.call
    end

    def execute_if_updated
      false
    end
  end

  def setup
    CountingWatcher.reset!
    @reloader = ActionView::CacheExpiry::ViewReloader.new(watcher: CountingWatcher)
  end

  def teardown
    # Drop the rebuild_watcher hook this reloader registered in the global
    # PathRegistry so it can't fire during later tests.
    ActionView::PathRegistry.file_system_resolver_hooks.delete_if do |hook|
      hook.respond_to?(:receiver) && hook.receiver.equal?(@reloader)
    end
  end

  test "updated? does not build a watcher when there are no view paths to watch" do
    @reloader.define_singleton_method(:dirs_to_watch) { [] }

    assert_nil @reloader.instance_variable_get(:@watcher)
    refute @reloader.updated?
    assert_nil @reloader.instance_variable_get(:@watcher),
      "ViewReloader should not materialize a watcher when there are no view paths"
    assert_equal 0, CountingWatcher.built
  end

  test "rebuild_watcher is a no-op while @watcher has not been built" do
    @reloader.define_singleton_method(:dirs_to_watch) { [] }

    @reloader.updated?

    # Simulate the `cast_file_system_resolvers` callback firing while no view
    # paths are registered — common during early Rails boot when an Engine
    # has not yet run its on_load(:action_mailer) hook.
    @reloader.send(:rebuild_watcher)

    assert_nil @reloader.instance_variable_get(:@watcher)
    assert_equal 0, CountingWatcher.built
  end

  test "updated? builds a watcher once view paths are registered" do
    paths = []
    @reloader.define_singleton_method(:dirs_to_watch) { paths }

    @reloader.updated?
    assert_equal 0, CountingWatcher.built

    paths << File.expand_path("fixtures", __dir__)
    @reloader.updated?

    assert_not_nil @reloader.instance_variable_get(:@watcher),
      "ViewReloader should materialize a watcher once there are view paths"
    assert_equal 1, CountingWatcher.built
  end

  test "rebuild_watcher rebuilds the watcher after the first build" do
    paths = [File.expand_path("fixtures", __dir__)]
    @reloader.define_singleton_method(:dirs_to_watch) { paths.dup }

    @reloader.updated?
    assert_equal 1, CountingWatcher.built

    paths = paths + [File.expand_path("../fixtures/test", __dir__)]
    @reloader.send(:rebuild_watcher)

    assert_equal 2, CountingWatcher.built
  end
end
