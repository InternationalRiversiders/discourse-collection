# frozen_string_literal: true

module DiscourseCollection
  # Turns a bare `/collections/:id` URL in a post body into a card (the link occupies a
  # line of its own) or into a titled link (the link sits inside a sentence, docs/12).
  # Registered against core's two local-onebox handlers, both of which dispatch on the
  # route's controller name — see plugin.rb for the registration itself.
  #
  # The card is baked into posts.cooked once and then served to every reader unchanged,
  # so it may only carry collection-level public data: no topic titles, no counts that
  # depend on who is reading, and none of the tile's role chip (owner / maintainer is a
  # per-visitor judgement, docs/03 §1).
  class OneboxHandler
    TEMPLATE_PATH = File.expand_path("onebox/templates/collection.mustache", __dir__)
    # Avatar shown next to the owner, matching the list tile's tiny avatar.
    AVATAR_SIZE = 24
    # What is asked of the avatar route. `/user_avatar/…/:size/…` serves only the sizes
    # core lists in SiteSetting.avatar_sizes, and the smaller ones are not always there to
    # be had. Asking for more than the card renders at also covers high-density screens,
    # which is what core does in the browser by scaling with the device pixel ratio first.
    AVATAR_REQUEST_SIZE = 48

    class << self
      # Core replaces the anchor with whatever this returns and treats an empty string as
      # "no onebox" — the post then keeps a plain link, and core will not try again.
      def handle(url, route, opts = nil)
        opts = cooking_opts(opts)
        collection = oneboxable_collection(route, opts)
        return "" unless collection

        Mustache.render(template, card_args(url, collection))
      end

      # The inline path only rewrites the link's text, so returning nil leaves the post
      # body exactly as the author typed it.
      def inline_handle(url, route, opts = nil)
        opts = cooking_opts(opts)
        collection = oneboxable_collection(route, opts)
        return unless collection

        title = I18n.t("discourse_collection.onebox.inline_title", name: collection.name)
        { url: url, title: title }
      end

      # Core's own handlers are called without the cooking options, so the category gate
      # reads the copy OneboxOptsForwarding parked on the thread. Whichever source has
      # something wins, which also keeps this working if core starts forwarding them.
      def cooking_opts(opts)
        opts.presence || OneboxOptsForwarding.current_opts || {}
      end

      # Read in development straight from disk so editing the template does not need a
      # process restart (the wording boards settled on, and the reason is the same).
      def template
        return File.read(TEMPLATE_PATH) if Rails.env.development?

        @template ||= File.read(TEMPLATE_PATH)
      end

      private

      def oneboxable_collection(route, opts)
        return unless SiteSetting.collection_enabled
        return unless SiteSetting.collection_onebox_enabled
        return unless route[:action] == "show"
        return if suppressed_category?(opts[:category_id])

        # The route only says the segment looks like an id; anything else must not reach
        # the query, where Postgres would raise on the cast.
        id = Integer(route[:id].to_s, exception: false)
        id && Collection.find_by(id: id)
      end

      # The gate is the category of the topic the post sits in, which core passes to the
      # oneboxer as an option — it is not read off the collection.
      def suppressed_category?(category_id)
        return false if category_id.blank?

        SiteSetting.collection_onebox_disabled_categories_map.include?(category_id.to_i)
      end

      # Flat, like core's own onebox templates: a section pushing a hash onto the context
      # is one more thing the template has to get right for no gain here.
      def card_args(url, collection)
        last_added_at = collection.last_topic_added_at

        {
          url: url,
          name: collection.name,
          description: collection.description,
          topic_count: collection.topic_count,
          subscriber_count: collection.subscribers_count,
          teamworker_count: co_worker_count(collection),
          owner: owner_args(collection),
          created_at_ms: time_ms(collection.created_at),
          created_at_text: absolute_date(collection.created_at),
          has_topics: last_added_at.present?,
          last_topic_added_at_ms: last_added_at && time_ms(last_added_at),
          last_topic_added_at_text: last_added_at && absolute_date(last_added_at),
          labels: labels,
        }
      end

      # Co-maintainers, i.e. the teamworker rows that are not the owner. The collection
      # stores no such count of its own: subscribers_count is about subscribers
      # (docs/03 §1).
      def co_worker_count(collection)
        CollectionTeamworker.where(collection_id: collection.id, is_owner: false).count
      end

      def owner_args(collection)
        owner = collection.owner
        return if owner.blank?

        {
          username: owner.username,
          avatar_url: owner.avatar_template_url.gsub("{size}", AVATAR_REQUEST_SIZE.to_s),
          avatar_size: AVATAR_SIZE,
        }
      end

      # Core's ticker rewrites the text of every `.relative-date` from `data-time` and
      # `data-format` (frontend/discourse/app/lib/formatter.js), so these values only have
      # to be right at bake time — there is no plugin-side JavaScript. The baked text is
      # an absolute date because it is what emails, digests and no-JS readers see, and a
      # stale "3 hours ago" would be worse than an exact timestamp.
      def time_ms(time)
        (time.to_f * 1000).to_i
      end

      def absolute_date(time)
        I18n.l(time, format: :long)
      end

      def labels
        {
          created_at: I18n.t("discourse_collection.onebox.created_at"),
          last_topic_added_at: I18n.t("discourse_collection.onebox.last_topic_added_at"),
          no_topics_yet: I18n.t("discourse_collection.onebox.no_topics_yet"),
          no_owner: I18n.t("discourse_collection.onebox.no_owner"),
          topic_count: I18n.t("discourse_collection.onebox.stats.topic_count"),
          subscriber_count: I18n.t("discourse_collection.onebox.stats.subscriber_count"),
          teamworker_count: I18n.t("discourse_collection.onebox.stats.teamworker_count"),
        }
      end
    end
  end
end
