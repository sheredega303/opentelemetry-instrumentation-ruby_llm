require "test_helper"

class InstrumentationTest < Minitest::Test
  include ChatCompletionStubs

  def setup
    EXPORTER.reset

    RubyLLM.configure do |c|
      c.openai_api_key = "fake-key-for-testing"
      c.anthropic_api_key = "fake-key-for-testing"
    end
  end

  def test_compatible_is_true_for_current_ruby_llm_version
    instrumentation = OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance
    assert_equal true, instrumentation.compatible?
  end

  def test_compatible_is_false_when_ruby_llm_below_minimum
    original_version = ::RubyLLM::VERSION
    ::RubyLLM.send(:remove_const, :VERSION)
    ::RubyLLM.const_set(:VERSION, "1.7.99")

    instrumentation = OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance
    assert_equal false, instrumentation.compatible?
  ensure
    ::RubyLLM.send(:remove_const, :VERSION)
    ::RubyLLM.const_set(:VERSION, original_version)
  end

  def test_compatible_is_false_when_ruby_llm_major_is_unsupported
    original_version = ::RubyLLM::VERSION
    ::RubyLLM.send(:remove_const, :VERSION)
    ::RubyLLM.const_set(:VERSION, "3.0.0")

    instrumentation = OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance
    assert_equal false, instrumentation.compatible?
  ensure
    ::RubyLLM.send(:remove_const, :VERSION)
    ::RubyLLM.const_set(:VERSION, original_version)
  end

  def test_minimum_ruby_llm_version_is_pinned_at_1_8_0
    assert_equal "1.8.0", OpenTelemetry::Instrumentation::RubyLLM::Instrumentation::MINIMUM_RUBY_LLM_VERSION
  end

  def test_agent_minimum_ruby_llm_version_is_pinned_at_1_12_1
    assert_equal "1.12.1", OpenTelemetry::Instrumentation::RubyLLM::Instrumentation::AGENT_MINIMUM_RUBY_LLM_VERSION
  end

  def test_creates_span_with_attributes
    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi")

    spans = EXPORTER.finished_spans
    assert_equal 1, spans.length

    span = spans.first
    assert_equal OpenTelemetry::Trace::SpanKind::CLIENT, span.kind
    assert_equal "chat gpt-4o-mini", span.name
    assert_equal "openai", span.attributes["gen_ai.provider.name"]
    assert_equal "gpt-4o-mini", span.attributes["gen_ai.request.model"]
    assert_equal "chat", span.attributes["gen_ai.operation.name"]
    # Per GenAI semconv, `gen_ai.request.stream` is set only when streaming.
    assert_nil span.attributes["gen_ai.request.stream"]
    assert_equal 10, span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 5, span.attributes["gen_ai.usage.output_tokens"]
  end

  def test_marks_streaming_chat_requests
    stub_chat_completion(
      chat_completion_body(content: "Hi", usage: { input_tokens: 1, output_tokens: 1 })
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi") { |_chunk| }

    span = EXPORTER.finished_spans.first
    assert_equal true, span.attributes["gen_ai.request.stream"]
  end

  def test_records_openai_prompt_cache_read_tokens
    # OpenAI exposes only `cached_tokens` (via `prompt_tokens_details` on Chat
    # Completions, `input_tokens_details` on the Responses API). The accessor
    # itself was added in ruby_llm 1.9.0.
    unless RUBY_LLM_V2 || RubyLLM::Message.instance_methods.include?(:cached_tokens)
      skip "cached_tokens accessor not available before ruby_llm 1.9.0"
    end

    stub_chat_completion(
      chat_completion_body(
        content: "Hello!",
        usage: { input_tokens: 25, output_tokens: 5, cached_tokens: 75 }
      )
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal 75, span.attributes["gen_ai.usage.cache_read.input_tokens"]

    if RUBY_LLM_V2
      # OpenAI's Responses API reports no cache-write counter and ruby_llm 2.0
      # passes that absence through (`protocols/responses/chat.rb#parse_usage`),
      # where 1.x's Chat Completions provider defaulted it to 0. Absence is
      # what the semconv asks for when the provider reports nothing.
      assert_nil span.attributes["gen_ai.usage.cache_creation.input_tokens"]
    else
      assert_equal 0, span.attributes["gen_ai.usage.cache_creation.input_tokens"]
    end
  end

  def test_records_anthropic_prompt_cache_tokens
    # Anthropic's provider surfaces both cache-read (via
    # `cache_read_input_tokens`) and cache-write (via
    # `cache_creation_input_tokens`). Accessors were added in ruby_llm 1.9.0.
    unless RUBY_LLM_V2 || RubyLLM::Message.instance_methods.include?(:cache_creation_tokens)
      skip "cache token accessors not available before ruby_llm 1.9.0"
    end

    stub_request(:post, "https://api.anthropic.com/v1/messages")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: "msg_cache",
          type: "message",
          role: "assistant",
          model: ANTHROPIC_MODEL,
          content: [{ type: "text", text: "Hello!" }],
          stop_reason: "end_turn",
          usage: {
            input_tokens: 100,
            output_tokens: 5,
            cache_read_input_tokens: 75,
            cache_creation_input_tokens: 20
          }
        }.to_json
      )

    chat = RubyLLM.chat(model: ANTHROPIC_MODEL)
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal 75, span.attributes["gen_ai.usage.cache_read.input_tokens"]
    assert_equal 20, span.attributes["gen_ai.usage.cache_creation.input_tokens"]
  end

  def test_records_error_on_api_failure
    stub_chat_completion_failure

    chat = RubyLLM.chat(model: "gpt-4o-mini")

    assert_raises do
      chat.ask("Hi")
    end

    spans = EXPORTER.finished_spans
    span = spans.last

    assert_equal "chat gpt-4o-mini", span.name
    assert span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_instruments_complete_called_directly
    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.add_message(role: :user, content: "Hi")
    chat.complete

    spans = EXPORTER.finished_spans
    assert_equal 1, spans.length

    span = spans.first
    assert_equal "chat gpt-4o-mini", span.name
    assert_equal "chat", span.attributes["gen_ai.operation.name"]
    assert_equal "openai", span.attributes["gen_ai.provider.name"]
    assert_equal 10, span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 5, span.attributes["gen_ai.usage.output_tokens"]
  end

  def test_creates_span_for_tool_call
    calculator = Class.new(RubyLLM::Tool) do
      def self.name = "calculator"
      description "Performs math"
      tool_parameter :expression, type: "string", description: "Math expression"

      def execute(expression:)
        eval(expression).to_s
      end
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{ id: "call_abc123", name: "calculator", arguments: '{"expression":"2+2"}' }]
      ),
      chat_completion_body(
        content: "The answer is 4",
        usage: { input_tokens: 20, output_tokens: 5 }
      )
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    with_tool(chat, calculator)
    chat.ask("What is 2+2?")

    spans = EXPORTER.finished_spans

    tool_spans = spans.select { |s| s.name.start_with?("execute_tool ") }
    chat_spans = spans.select { |s| s.name.include?("chat ") }

    assert_equal 1, tool_spans.length
    assert_equal 2, chat_spans.length

    tool_span = tool_spans.first
    assert_equal OpenTelemetry::Trace::SpanKind::INTERNAL, tool_span.kind
    assert_equal "execute_tool calculator", tool_span.name
    assert_equal "execute_tool", tool_span.attributes["gen_ai.operation.name"]
    assert_equal "calculator", tool_span.attributes["gen_ai.tool.name"]
    assert_equal "Performs math", tool_span.attributes["gen_ai.tool.description"]
    assert_equal '{"expression":"2+2"}', tool_span.attributes["gen_ai.tool.call.arguments"]
    assert_equal "4", tool_span.attributes["gen_ai.tool.call.result"]
    assert_equal "call_abc123", tool_span.attributes["gen_ai.tool.call.id"]
    assert_equal "function", tool_span.attributes["gen_ai.tool.type"]
  end

  # A turn that calls a tool must stay one trace: 1.x nests it by recursing,
  # 2.0 needs the `chat_turn` wrapper. Asserted as a shape, not by span name,
  # so the test is honest on both majors.
  def test_tool_call_turn_is_a_single_trace
    calculator = Class.new(RubyLLM::Tool) do
      def self.name = "calculator"
      description "Performs math"
      tool_parameter :expression, type: "string", description: "Math expression"

      def execute(expression:)
        eval(expression).to_s
      end
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{ id: "call_abc123", name: "calculator", arguments: '{"expression":"2+2"}' }]
      ),
      chat_completion_body(content: "The answer is 4")
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    with_tool(chat, calculator)
    chat.ask("What is 2+2?")

    spans = EXPORTER.finished_spans
    roots = spans.select { |s| s.parent_span_id == OpenTelemetry::Trace::INVALID_SPAN_ID }

    assert_equal 1, spans.map(&:trace_id).uniq.length, "tool turn split across traces"
    assert_equal 1, roots.length, "tool turn produced more than one root span"

    if RUBY_LLM_V2
      # The wrapper is INTERNAL and named apart from `chat` on purpose: a
      # `chat` span means exactly one provider request on every version.
      assert_equal "chat_turn gpt-4o-mini", roots.first.name
      assert_equal OpenTelemetry::Trace::SpanKind::INTERNAL, roots.first.kind
      assert_equal "chat_turn", roots.first.attributes["gen_ai.operation.name"]
      refute roots.first.attributes.key?("gen_ai.usage.input_tokens"), "wrapper must not double-count usage"
    else
      assert_equal "chat gpt-4o-mini", roots.first.name
    end
  end

  # The wrapper exists only to hold a multi-request turn together, so a chat
  # without tools must keep emitting the single `chat` span it emits on 1.x.
  def test_chat_without_tools_emits_no_turn_span
    stub_chat_completion(chat_completion_body)

    RubyLLM.chat(model: "gpt-4o-mini").ask("Hi")

    spans = EXPORTER.finished_spans

    assert_equal 1, spans.length
    assert_equal "chat gpt-4o-mini", spans.first.name
  end

  def test_truncates_tool_result_to_configured_max_length
    long_value = "x" * 1000
    echo = Class.new(RubyLLM::Tool) do
      def self.name = "echo"
      description "Echoes a long string"

      define_method(:execute) { long_value }
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{ id: "call_echo", name: "echo", arguments: "{}" }]
      ),
      chat_completion_body(
        content: "done",
        usage: { input_tokens: 20, output_tokens: 5 }
      )
    )

    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:tool_result_max_length] = 700

    chat = with_tool(RubyLLM.chat(model: "gpt-4o-mini"), echo)
    chat.ask("echo please")

    tool_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("execute_tool ") }
    assert_equal "x" * 700, tool_span.attributes["gen_ai.tool.call.result"]
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:tool_result_max_length] = 500
  end

  def test_serializes_hash_tool_result_as_json
    structured_tool = Class.new(RubyLLM::Tool) do
      def self.name = "structured_tool"
      description "Returns structured data"

      def execute
        { answer: 4, source: "calculator" }
      end
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        # Both majors strip a trailing "_tool" from the class name, so the
        # model calls `structured_tool` "structured".
        tool_calls: [{ id: "call_structured", name: "structured", arguments: "{}" }]
      ),
      chat_completion_body(
        content: "The answer is 4",
        usage: { input_tokens: 20, output_tokens: 5 }
      )
    )

    with_tool(RubyLLM.chat(model: "gpt-4o-mini"), structured_tool).ask("What is 2+2?")

    tool_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("execute_tool ") }
    assert_equal({ "answer" => 4, "source" => "calculator" }, JSON.parse(tool_span.attributes["gen_ai.tool.call.result"]))
  end

  def test_records_error_when_tool_raises
    boom = Class.new(RubyLLM::Tool) do
      def self.name = "boom"
      description "Always raises"

      def execute
        raise ArgumentError, "tool failure"
      end
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{ id: "call_x", name: "boom", arguments: "{}" }],
        usage: { input_tokens: 1, output_tokens: 1 }
      )
    )

    chat = with_tool(RubyLLM.chat(model: "gpt-4o-mini"), boom)
    assert_raises(ArgumentError) { chat.ask("trigger") }

    tool_span = EXPORTER.finished_spans.find { |s| s.name.start_with?("execute_tool ") }
    assert_equal "ArgumentError", tool_span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, tool_span.status.code
  end

  def test_does_not_capture_content_by_default
    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_instructions("You are helpful")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_nil span.attributes["gen_ai.system_instructions"]
    assert_nil span.attributes["gen_ai.input.messages"]
    assert_nil span.attributes["gen_ai.output.messages"]
  end

  def test_captures_content_when_enabled
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_instructions("You are helpful")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first

    system_instructions = JSON.parse(span.attributes["gen_ai.system_instructions"])
    assert_equal [{ "type" => "text", "content" => "You are helpful" }], system_instructions

    input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
    assert_equal 1, input_messages.length
    assert_equal "user", input_messages[0]["role"]
    assert_equal [{ "type" => "text", "content" => "Hi" }], input_messages[0]["parts"]

    output_messages = JSON.parse(span.attributes["gen_ai.output.messages"])
    assert_equal 1, output_messages.length
    assert_equal "assistant", output_messages[0]["role"]
    assert_equal [{ "type" => "text", "content" => "Hello, world!" }], output_messages[0]["parts"]
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
  end

  def test_creates_span_for_embedding
    stub_request(:post, "https://api.openai.com/v1/embeddings")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          object: "list",
          model: "text-embedding-3-small",
          data: [
            { object: "embedding", index: 0, embedding: [0.1, 0.2, 0.3] }
          ],
          usage: { prompt_tokens: 8, total_tokens: 8 }
        }.to_json
      )

    RubyLLM.embed("Hello, world!", model: "text-embedding-3-small")

    spans = EXPORTER.finished_spans
    assert_equal 1, spans.length

    span = spans.first
    assert_equal OpenTelemetry::Trace::SpanKind::CLIENT, span.kind
    assert_equal "embeddings text-embedding-3-small", span.name
    assert_equal "embeddings", span.attributes["gen_ai.operation.name"]
    assert_equal "openai", span.attributes["gen_ai.provider.name"]
    assert_equal "text-embedding-3-small", span.attributes["gen_ai.request.model"]
    assert_equal "text-embedding-3-small", span.attributes["gen_ai.response.model"]
    assert_equal 8, span.attributes["gen_ai.usage.input_tokens"]
    assert_equal 3, span.attributes["gen_ai.embeddings.dimension.count"]
  end

  def test_records_error_on_embedding_api_failure
    stub_request(:post, "https://api.openai.com/v1/embeddings")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises do
      RubyLLM.embed("Hello", model: "text-embedding-3-small")
    end

    spans = EXPORTER.finished_spans
    span = spans.last

    assert_equal "embeddings text-embedding-3-small", span.name
    assert span.attributes["error.type"]
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  end

  def test_with_otel_attributes_sets_span_attributes
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_otel_attributes(
      "langfuse.trace.tags" => ["vitamin_d3"],
      "custom.category" => "supplements"
    )
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal ["vitamin_d3"], span.attributes["langfuse.trace.tags"]
    assert_equal "supplements", span.attributes["custom.category"]
  end

  # Backends like Langfuse read trace-level attributes off the root span, so
  # every root must carry them — including 2.0's `chat_turn` wrapper.
  def test_with_otel_attributes_reach_the_trace_root_of_a_tool_turn
    calculator = Class.new(RubyLLM::Tool) do
      def self.name = "calculator"
      description "Performs math"
      tool_parameter :expression, type: "string", description: "Math expression"

      def execute(expression:)
        eval(expression).to_s
      end
    end

    stub_chat_completion(
      chat_completion_body(
        content: nil,
        tool_calls: [{ id: "call_abc123", name: "calculator", arguments: '{"expression":"2+2"}' }]
      ),
      chat_completion_body(content: "The answer is 4")
    )

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    with_tool(chat, calculator)
    chat.with_otel_attributes("langfuse.session.id" => "session-1")
    chat.ask("What is 2+2?")

    root = EXPORTER.finished_spans.find { |s| s.parent_span_id == OpenTelemetry::Trace::INVALID_SPAN_ID }
    assert_equal "session-1", root.attributes["langfuse.session.id"]
  end

  def test_with_otel_attributes_returns_self_for_chaining
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    result = chat.with_otel_attributes("custom.category" => "test")

    assert_same chat, result
  end

  def test_with_otel_attributes_evaluates_callables
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_otel_attributes(
      "custom.last_role" => -> { chat.messages.last&.role.to_s },
      "custom.static" => "fixed"
    )
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first
    assert_equal "assistant", span.attributes["custom.last_role"]
    assert_equal "fixed", span.attributes["custom.static"]
  end

  def test_with_otel_attributes_applied_on_api_failure
    stub_chat_completion_failure

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.with_otel_attributes(
      "langfuse.trace.name" => "My Agent",
      "custom.last_role" => -> { chat.messages.last&.role.to_s }
    )

    assert_raises do
      chat.ask("Hi")
    end

    span = EXPORTER.finished_spans.last
    assert_equal "chat gpt-4o-mini", span.name
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    assert_equal "My Agent", span.attributes["langfuse.trace.name"]
    assert_equal "user", span.attributes["custom.last_role"]
  end

  def test_works_without_otel_attributes
    stub_chat_completion(chat_completion_body(content: "Hello!"))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    response = chat.ask("Hi")

    assert_equal "Hello!", response.content
  end

  def test_captures_message_attachments
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

    stub_chat_completion(chat_completion_body(content: "A cat."))

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.add_message(role: :user, **attachment_message("What is this?", "https://example.com/cat.png"))
    chat.complete

    span = EXPORTER.finished_spans.first
    input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
    assert_equal(
      [
        { "type" => "text", "content" => "What is this?" },
        {
          "type" => "uri",
          "modality" => "image",
          "mime_type" => "image/png",
          "uri" => "https://example.com/cat.png"
        }
      ],
      input_messages[0]["parts"]
    )
  ensure
    OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
  end

  if RUBY_LLM_V2
    # ruby_llm 2.0 deleted `RubyLLM::Content::Raw`, so its job here —
    # proving extra payload reaches `gen_ai.system_instructions`, not just
    # `gen_ai.input.messages` — falls to `Message#attachments`.
    def test_captures_system_instructions_with_attachments
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

      stub_chat_completion(chat_completion_body(content: "Acknowledged."))

      chat = RubyLLM.chat(model: "gpt-4o-mini")
      chat.add_message(
        role: :system,
        content: "You are helpful",
        attachments: "https://example.com/cat.png"
      )
      chat.add_message(role: :user, content: "Hi")
      chat.complete

      span = EXPORTER.finished_spans.first
      system_instructions = JSON.parse(span.attributes["gen_ai.system_instructions"])
      assert_equal(
        [
          { "type" => "text", "content" => "You are helpful" },
          {
            "type" => "uri",
            "modality" => "image",
            "mime_type" => "image/png",
            "uri" => "https://example.com/cat.png"
          }
        ],
        system_instructions
      )
    ensure
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
    end
  else
    def test_captures_ruby_llm_content_raw
      skip "RubyLLM::Content::Raw not available before ruby_llm 1.9.0" unless defined?(RubyLLM::Content::Raw)
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

      stub_chat_completion(chat_completion_body(content: "Acknowledged."))

      raw = RubyLLM::Content::Raw.new([{ type: "text", text: "raw payload" }])

      chat = RubyLLM.chat(model: "gpt-4o-mini")
      chat.add_message(role: :user, content: raw)
      chat.complete

      span = EXPORTER.finished_spans.first
      input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
      assert_equal(
        [{ "type" => "raw", "content" => [{ "type" => "text", "text" => "raw payload" }].to_json }],
        input_messages[0]["parts"]
      )
    ensure
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
    end

    def test_captures_ruby_llm_content_raw_system_instructions
      skip "RubyLLM::Content::Raw not available before ruby_llm 1.9.0" unless defined?(RubyLLM::Content::Raw)
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = true

      stub_chat_completion(chat_completion_body(content: "Acknowledged."))

      raw_block = RubyLLM::Content::Raw.new([{ type: "text", text: "You are helpful" }])

      chat = RubyLLM.chat(model: "gpt-4o-mini")
      chat.add_message(role: :system, content: raw_block)
      chat.add_message(role: :user, content: "Hi")
      chat.complete

      span = EXPORTER.finished_spans.first
      system_instructions = JSON.parse(span.attributes["gen_ai.system_instructions"])
      assert_equal(
        [{ "type" => "raw", "content" => [{ "type" => "text", "text" => "You are helpful" }].to_json }],
        system_instructions
      )
    ensure
      OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.config[:capture_content] = false
    end
  end

  def test_captures_content_when_enabled_via_env_var
    ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = "true"

    stub_chat_completion

    chat = RubyLLM.chat(model: "gpt-4o-mini")
    chat.ask("Hi")

    span = EXPORTER.finished_spans.first

    input_messages = JSON.parse(span.attributes["gen_ai.input.messages"])
    assert_equal "user", input_messages[0]["role"]

    output_messages = JSON.parse(span.attributes["gen_ai.output.messages"])
    assert_equal "assistant", output_messages[0]["role"]
  ensure
    ENV.delete("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT")
  end

  private

  # A message's text and its files live in one `RubyLLM::Content` on 1.x and
  # in separate `content`/`attachments` on 2.0, which deleted `Content`.
  def attachment_message(text, url)
    if RUBY_LLM_V2
      { content: text, attachments: url }
    else
      { content: RubyLLM::Content.new(text, url) }
    end
  end
end
