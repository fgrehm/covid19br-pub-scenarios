class Scenario
  def initialize(guid:, name:, description:)
    @agents = {}
    @guid = guid
    @name = name
    @description = description
  end

  def register_agents(*agents)
    Array(agents).flatten.compact.each do |agent|
      raise ArgumentError, agent[:guid] if @agents.key?(agent[:guid])

      @agents[agent[:guid]] = agent
    end
  end

  def as_json
    {
      schema_version: 1,
      name: @name,
      description: @description,
      guid: @guid,
      exported_at: Time.now.strftime('%Y-%m-%d %H:%M:%S %z'),
      agents: serialize_agents,
      links: generate_links
    }
  end

  private

  def serialize_agents
    @agents.values.map { |agent| serialize_agent(agent) }
  end

  def serialize_agent(agent)
    serialized = agent.merge(guid: "#{@guid}-#{agent[:guid]}")
    serialized.delete(:targets)
    serialized
  end

  def generate_links
    links = @agents.each_with_object({}) { |(k, a), h| h[k] = Array(a[:targets]) }
    agent_keys = @agents.keys
    links.map do |source, receivers|
      source_idx = agent_keys.index(source)
      receivers.map { |r| { source: source_idx, receiver: agent_keys.index(r) } }
    end.flatten.compact
  end
end
