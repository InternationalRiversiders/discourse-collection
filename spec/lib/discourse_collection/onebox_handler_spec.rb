# frozen_string_literal: true

RSpec.describe DiscourseCollection::OneboxHandler do
  fab!(:user)
  fab!(:category)

  def build_collection(name: "Reading list", description: "", owner: user, **attrs)
    collection = Fabricate(:collection, name:, description:, **attrs)
    Fabricate(:collection_teamworker, collection:, user: owner, is_owner: true) if owner
    collection
  end

  def route_to(collection)
    {
      controller: "discourse_collection/collections",
      action: "show",
      id: collection.id.to_s,
    }
  end

  def url_for(collection)
    "#{Discourse.base_url}/collections/#{collection.id}"
  end

  def card(collection, opts = {})
    described_class.handle(url_for(collection), route_to(collection), opts)
  end

  before { SiteSetting.collection_onebox_enabled = true }

  describe "the card" do
    it "renders the collection inside core's onebox shell" do
      collection = build_collection(name: "Reading list", description: "Good reads")

      html = card(collection)

      expect(html).to include(%(<aside class="onebox collection-onebox">))
      expect(html).to include("Reading list")
      expect(html).to include("Good reads")
      expect(html).to include(url_for(collection))
    end

    it "links the collection from its name, leaving the card itself unlinked" do
      collection = build_collection

      html = card(collection)
      name_link = html[%r{<a href="#{Regexp.escape(url_for(collection))}">.*?</a>}m]

      # The plugin's own icon sits inside the link, ahead of the name.
      expect(name_link).to include(%(<use href="#collection"></use>))
      expect(name_link).to include("Reading list")
      # The name and the owner, and nothing wrapping the card — an anchor cannot nest.
      expect(html.scan("<a ").size).to eq(2)
    end

    it "carries the owner as one anchor holding both the face and the name" do
      html = card(build_collection)

      expect(html).to include(%(data-user-card="#{user.username}"))
      expect(html).to include(%(src="#{user.avatar_template_url.gsub("{size}", "48")}"))
      expect(html).to include(%(width="24" height="24"))
      expect(html).to include(
        %(<span class="collection-onebox__owner-name">#{user.username}</span>),
      )
    end

    # An anchor in cooked HTML that carries an href is claimed by core's click tracking —
    # bound on the topic element, which the card listener on #main-outlet sits below — and
    # the page is routed away before the card can stay open.
    it "leaves the owner anchor without an href, so only the card opens" do
      anchor = card(build_collection)[%r{<a [^>]*collection-onebox__owner-link[^>]*>}]

      expect(anchor).to include(%(data-user-card="#{user.username}"))
      expect(anchor).not_to include("href")
    end

    # The avatar route serves only the sizes core lists in SiteSetting.avatar_sizes, and a
    # size it does not list is what broke the card — User#small_avatar_url asks for 45.
    # Guards the constant against core reshuffling those defaults again.
    it "asks the avatar route for a size the site serves" do
      expect(Discourse.avatar_sizes).to include(described_class::AVATAR_REQUEST_SIZE)
    end

    it "marks an ownerless collection the way the list tile does" do
      expect(card(build_collection(owner: nil))).to include(
        %(<span class="collection-onebox__owner-name -unclaimed">Unclaimed</span>),
      )
    end

    it "counts co-maintainers only, never the owner" do
      collection = build_collection
      2.times do
        Fabricate(:collection_teamworker, collection:, user: Fabricate(:user), is_owner: false)
      end

      expect(card(collection)).to match(%r{<use href="#user-group"></use></svg>\s*2\s*</span>})
    end

    # The browser re-renders these from `data-time` (docs/12 §5), and core's own ticker
    # only knows how to shorten them past five days — the plugin's initializer needs the
    # elements to itself.
    it "stamps the dates for the browser, and words the fallback in UTC" do
      collection = build_collection
      collection.update!(topic_count: 1, last_topic_added_at: Time.zone.now)
      collection.reload

      html = card(collection)

      expect(html).to include(%(data-time="#{(collection.created_at.to_f * 1000).to_i}"))
      expect(html).to include(
        %(<span class="collection-onebox__date" data-time="#{(collection.last_topic_added_at.to_f * 1000).to_i}">),
      )
      expect(html).not_to include("relative-date")
      # What a mail digest, or a reader without JavaScript, sees. Baking happens in the
      # server's zone, so the text carries the marker.
      expect(html).to include("#{I18n.l(collection.created_at, format: :long)} UTC")
      expect(html).to include("Created")
      expect(html).to include("Updated")
    end

    it "falls back to the empty-collection wording when nothing is collected yet" do
      collection = build_collection

      expect(collection.last_topic_added_at).to be_nil
      expect(card(collection)).to include(
        %(<span class="collection-onebox__activity -none">No topics yet</span>),
      )
    end

    it "escapes what the collection carries" do
      collection = build_collection(
        name: "<b>Bold</b> & friends",
        description: %(say "<script>alert(1)</script>"),
      )

      html = card(collection)

      expect(html).to include("&lt;b&gt;Bold&lt;/b&gt; &amp; friends")
      expect(html).not_to include("<b>Bold</b>")
      expect(html).not_to include("<script>")
    end
  end

  describe "the guards" do
    it "returns no card while the onebox setting is off" do
      SiteSetting.collection_onebox_enabled = false

      expect(card(build_collection)).to eq("")
    end

    it "returns no card while the plugin is off" do
      SiteSetting.collection_enabled = false

      expect(card(build_collection)).to eq("")
    end

    it "returns no card for a collection that does not exist" do
      collection = build_collection
      collection.destroy!

      expect(described_class.handle(url_for(collection), route_to(collection))).to eq("")
    end

    it "returns no card for a route that is not the collection's own page" do
      collection = build_collection
      route = route_to(collection).merge(action: "mine")

      expect(described_class.handle(url_for(collection), route)).to eq("")
    end

    it "returns no card for an id that is not a number, rather than failing the cast" do
      collection = build_collection
      route = route_to(collection).merge(id: "not-a-number")

      expect(described_class.handle(url_for(collection), route)).to eq("")
    end

    it "returns no card in a category the admin suppressed" do
      SiteSetting.collection_onebox_disabled_categories = category.id.to_s

      expect(card(build_collection, category_id: category.id)).to eq("")
    end

    it "still renders the card in every other category" do
      SiteSetting.collection_onebox_disabled_categories = Fabricate(:category).id.to_s

      expect(card(build_collection, category_id: category.id)).to include("Reading list")
    end

    it "renders the card where no category is in play at all" do
      SiteSetting.collection_onebox_disabled_categories = category.id.to_s

      expect(card(build_collection)).to include("Reading list")
    end
  end

  describe ".inline_handle" do
    it "replaces the link text with the collection and the product name" do
      collection = build_collection(name: "Reading list")

      expect(
        described_class.inline_handle(url_for(collection), route_to(collection)),
      ).to eq(url: url_for(collection), title: "Reading list - Collections")
    end

    it "obeys the same guards as the card" do
      collection = build_collection
      SiteSetting.collection_onebox_disabled_categories = category.id.to_s

      expect(
        described_class.inline_handle(
          url_for(collection),
          route_to(collection),
          category_id: category.id,
        ),
      ).to be_nil
      expect(described_class.inline_handle(url_for(collection), route_to(collection))).to be_present
    end
  end

  describe "the registered handlers" do
    # The dispatchers are keyed by the route's controller name, and a key that does not
    # match the engine's namespace fails silently — only a real lookup catches that.
    it "answers Oneboxer end to end" do
      collection = build_collection(name: "Reading list")

      expect(Oneboxer.preview(url_for(collection))).to include("Reading list")
    end

    it "answers InlineOneboxer end to end" do
      collection = build_collection(name: "Reading list")

      expect(InlineOneboxer.lookup(url_for(collection), invalidate: true)).to eq(
        url: url_for(collection),
        title: "Reading list - Collections",
      )
    end

    # The dispatchers drop the cooking options before calling a handler; the category gate
    # reads them back off the thread, so this only passes with the prepends in place.
    it "sees the category the post is being cooked in" do
      collection = build_collection
      other_category = Fabricate(:category)
      SiteSetting.collection_onebox_disabled_categories = category.id.to_s

      expect(Oneboxer.preview(url_for(collection), category_id: category.id)).not_to include(
        "Reading list",
      )
      expect(Oneboxer.preview(url_for(collection), category_id: other_category.id)).to include(
        "Reading list",
      )
    end
  end
end
