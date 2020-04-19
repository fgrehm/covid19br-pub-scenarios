class SourceIngestionScenario
  def self.build(config)
    new(config).build
  end

  def initialize(config)
    @config = config.dup
    @metadata = @config.delete("metadata")
    @inputs = @config.delete("inputs")
    @version = @config.delete("version") || "v1"
    @scenario = Scenario.new(
      guid: "#{@metadata["source_guid"]}-#{@version}",
      name: "#{@metadata["short_name"]} (#{@version})",
      description: @metadata["description"]
    )
  end

  def build
    @scenario.register_agents(twitter_ingestion)
    @scenario.register_agents(articles_ingestion)
    @scenario.register_agents(s3_upload)
    @built = true
    self
  end

  def as_json
    build if !@built
    @scenario.as_json
  end

  private

  def agent_name(name)
    "#{@metadata["short_name"]} (#{@version}) - #{name}"
  end

  #############################################################################
  # Twitter
  #############################################################################

  def twitter_ingestion
    return [] unless @inputs.key?("tweets")

    [twitter_timeline_agent(@inputs["tweets"]),
     twitter_wrap_agent,
     twitter_format_agent]
  end

  def twitter_timeline_agent(tweets_config)
    {
      type: "Agents::TwitterUserAgent",
      name: agent_name("Twitter Ingestion - Timeline Watcher"),
      guid: "twitter-timeline",
      disabled: false,
      options: {
        username: tweets_config["user"],
        include_retweets: "true",
        exclude_replies: "false",
        expected_update_period_in_days: "1",
        choose_home_time_line: "false",
        starting_at: "2020-01-01 00:00:00 +0000"
      },
      schedule: "every_5m",
      keep_events_for: 60 * 60 * 24 * 7, # 1 week
      targets: "twitter-wrap"
    }
  end

  def twitter_wrap_agent
    {
      type: "Agents::JavaScriptAgent",
      name: agent_name("Twitter Ingestion - Wrap"),
      disabled: false,
      guid: "twitter-wrap",
      options: {
        language: "JavaScript",
        code: <<-JS.gsub("\n", "\r"),
Agent.receive = function() {
  var events = this.incomingEvents();
  for(var i = 0; i < events.length; i++) {
    var payload = events[i].payload;
    this.createEvent({ tweet: payload });
  }
}
        JS
        expected_receive_period_in_days: "1",
        expected_update_period_in_days: "1"
      },
      schedule: "never",
      keep_events_for: 60 * 60 * 24, # 1 day
      propagate_immediately: false,
      targets: "twitter-format"
    }
  end

  def twitter_format_agent
    {
      type: "Agents::EventFormattingAgent",
      name: agent_name("Twitter Ingestion - Format"),
      guid: "twitter-format",
      disabled: false,
      options: {
        instructions: {
          full_text: "{{ tweet.full_text | strip }}",
          image_url: "{% assign medium = tweet.entities.media | first %}{{ medium.media_url_https }}",
          published_at: "{{ created_at | date: \"%Y-%m-%d %H:%M:%S %z\" }}",
          found_at: "{{ \"now\" | date: \"%Y-%m-%d %H:%M:%S %z\" }}",
          url: "https://twitter.com/{{ tweet.user.screen_name }}/{{ tweet.id }}",
          content_type: "tweet"
        },
        matchers: [ ],
        mode: "merge"
      },
      keep_events_for: 60 * 60 * 24, # 1 day
      propagate_immediately: false,
      targets: "s3-prepare"
    }
  end

  #############################################################################
  # Articles
  #############################################################################

  def articles_ingestion
    return [] unless @inputs.key?("articles")

    [articles_rss_agents(@inputs["articles"]),
     articles_backfill_agents,
     articles_crawler_agents(@inputs["articles"]),
     articles_scraper_agents(@inputs["articles"])].flatten
  end

  def articles_rss_agents(articles_config)
    return [] unless articles_config.key?("rss")

    [
      {
        type: "Agents::RssAgent",
        name: agent_name("Articles Ingestion - RSS Watcher"),
        disabled: false,
        guid: "articles-rss-input",
        options: {
          expected_update_period_in_days: "1",
          clean: "true",
          url: articles_config["rss"].fetch("url")
        },
        schedule: "every_30m",
        keep_events_for: 60 * 60 * 24 * 30, # 1 month
        targets: "articles-rss-wrap"
      },
      {
        type: "Agents::JavaScriptAgent",
        name: agent_name("Articles Ingestion - RSS Wrap"),
        disabled: false,
        guid: "articles-rss-wrap",
        options: {
          language: "JavaScript",
          code: <<-JS.gsub("\n", "\r"),
Agent.receive = function() {
  var events = this.incomingEvents();
  for(var i = 0; i < events.length; i++) {
    var payload = events[i].payload;
    this.createEvent({ rss_item: payload, url: payload.url });
  }
}
          JS
          expected_receive_period_in_days: "1",
          expected_update_period_in_days: "1"
        },
        schedule: "never",
        keep_events_for: 60 * 60 * 24, # 1 day
        propagate_immediately: false,
        targets: "articles-scrape"
      }
    ]
  end

  def articles_backfill_agents
    [
      {
        type: "Agents::WebhookAgent",
        name: agent_name("Articles Ingestion - Manual Backfill"),
        disabled: false,
        guid: "articles-backfill",
        options: {
          secret: "{% credential webhooks-secret %}",
          expected_receive_period_in_days: "365",
          payload_path: "._json",
          event_headers: "",
          event_headers_key: "headers"
        },
        keep_events_for: 60 * 60 * 24 * 30, # 1 month
        targets: "articles-scrape"
      }
    ]
  end

  def articles_crawler_agents(articles_config)
    return [] unless articles_config.key?("crawler")

    crawler = articles_config["crawler"]
    if crawler["javascript"]
      articles_crawler_js_agents(crawler)
    else
      articles_crawler_simple_agents(crawler)
    end
  end

  def articles_crawler_js_agents(crawler)
    raise "NOT SUPPORTED YET"
    [
      {
      }
    ]
  end

  def articles_crawler_simple_agents(crawler)
    [
      {
        type: "Agents::WebsiteAgent",
        name: agent_name("Articles Ingestion - Crawler"),
        disabled: false,
        guid: "articles-crawler",
        options: {
          expected_update_period_in_days: "1",
          url: crawler.fetch("urls"),
          type: "html",
          mode: "on_change",
          extract: { url: crawler.fetch("link_extractor") },
          template: { url: "{{ url | to_uri: _response_.url }}" }
        },
        schedule: "every_30m",
        keep_events_for: 60 * 60 * 24 * 30, # 1 month
        propagate_immediately: false,
        targets: "articles-scrape"
      }
    ]
  end

  def articles_scraper_agents(articles_config)
    scraper = articles_config.fetch("scraper")

    [
      {
        type: "Agents::WebsiteAgent",
        name: agent_name("Articles Ingestion - Scrape"),
        disabled: false,
        guid: "articles-scrape",
        options: {
          expected_update_period_in_days: "1",
          url_from_event: "{{ url | strip }}",
          type: "html",
          mode: "merge",
          extract: {
            # TODO: Canonical
            # * parse <link rel="canonical" href="/noticias/bahia-tem-967-casos-confirmados-de-covid-19">
            # * meta[og:url]
          }.merge(scraper.fetch("extract")),
          template: {
            "title" => "{{ title | strip }}",
            "excerpt" => "{{ excerpt | strip }}",
            "full_text" => "{{ full_text | strip }}",
            "image_url" => "{% if image_url %}{{ image_url | strip | to_uri: _response_.url }}{% endif %}",
            # TODO: If canonical is set, use that
            # "url" => "{{ url | strip | to_uri: _response_.url }}",
            "url" => "{{ url | strip }}",
            "found_at" => "{{ \"now\" | date: \"%Y-%m-%d %H:%M:%S %z\" }}",
            "published_at" => "{{ published_at | strip | date: \"%Y-%m-%d %H:%M:%S %z\" }}",
            "updated_at" => "{{ updated_at | strip | date: \"%Y-%m-%d %H:%M:%S %z\" }}",
            "content_type" => "article"
          }.merge(scraper["template"] || {})
        },
        schedule: "never",
        keep_events_for: 60 * 60 * 24 * 30, # 1 month
        propagate_immediately: true,
        targets: "s3-prepare"
      }
    ]
  end

  #############################################################################
  # S3
  #############################################################################

  def s3_upload
    [s3_prepare_agent, s3_serialize_agent, s3_upload_agent]
  end

  def s3_prepare_agent
    {
      type: "Agents::EventFormattingAgent",
      name: agent_name("S3 Archive - Prepare"),
      disabled: false,
      guid: "s3-prepare",
      options: {
        instructions: {
          source_guid: @metadata["source_guid"],
          url_hash: "{{ url | sha1 }}",
          full_text_hash: "{{ full_text | sha1 }}",
          full_text: "{{ full_text | strip }}"
        },
        matchers: [ ],
        mode: "merge"
      },
      keep_events_for: 60 * 60 * 24, # 1 day
      propagate_immediately: true,
      targets: "s3-serialize"
    }
  end

  def s3_serialize_agent
    {
      type: "Agents::JavaScriptAgent",
      name: agent_name("S3 Archive - Serialize"),
      disabled: false,
      guid: "s3-serialize",
      options: {
        language: "JavaScript",
        code: <<-JS.gsub("\n", "\r"),
Agent.receive = function() {
  var events = this.incomingEvents();
  for(var i = 0; i < events.length; i++) {
    var payload = events[i].payload;
    var key = payload.source_guid + "/" + payload.content_type + "-" + payload.url_hash + ".json";
    payload.key = key;
    var serialized = JSON.stringify(payload);
    this.createEvent({ serialized: serialized, key: key });
  }
}
        JS
        expected_receive_period_in_days: "1",
        expected_update_period_in_days: "1"
      },
      schedule: "never",
      keep_events_for: 60 * 60 * 24 * 30, # 1 month
      propagate_immediately: false,
      targets: "s3-upload"
    }
  end

  def s3_upload_agent
    {
      type: "Agents::S3Agent",
      name: agent_name("S3 Archive - Upload"),
      disabled: false,
      guid: "s3-upload",
      options: {
        mode: "write",
        access_key_id: "{% credential aws-key-id %}",
        access_key_secret: "{% credential aws-key-secret %}",
        region: "us-east-1",
        watch: "false",
        bucket: "{% credential aws-bucket-input %}",
        filename: "{{ key }}",
        data: "{{ serialized }}"
      },
      schedule: "never",
      keep_events_for: 0,
      propagate_immediately: true
    }
  end
end
