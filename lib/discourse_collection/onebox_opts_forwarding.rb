# frozen_string_literal: true

module DiscourseCollection
  # Core calls a registered local-onebox handler with `(url, route)` only: the cooking
  # options stop at the two dispatchers and never reach the handler
  # (lib/oneboxer.rb `local_onebox`, lib/inline_oneboxer.rb `lookup`). The card needs one
  # of them — the category of the topic being cooked, which is what the
  # collection_onebox_disabled_categories gate is about.
  #
  # Prepending the two dispatchers parks the options on the current thread for the
  # duration of the call, where OneboxHandler reads them back. That keeps the handler's
  # signature forward-compatible: the day core passes the options down itself, the
  # handler already prefers the argument over the thread-local copy.
  module OneboxOptsForwarding
    OPTS_KEY = :discourse_collection_onebox_opts

    # The cooking options in effect, or nil outside a onebox call.
    def self.current_opts
      Thread.current[OPTS_KEY]
    end

    def self.storing(opts)
      previous = Thread.current[OPTS_KEY]
      Thread.current[OPTS_KEY] = opts
      yield
    ensure
      Thread.current[OPTS_KEY] = previous
    end

    # Prepended onto the singleton class of Oneboxer and of InlineOneboxer.
    module Patch
      def local_onebox(url, opts = {})
        OneboxOptsForwarding.storing(opts) { super }
      end

      def lookup(url, opts = nil)
        OneboxOptsForwarding.storing(opts) { super }
      end
    end
  end
end
