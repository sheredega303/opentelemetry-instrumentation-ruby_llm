# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Chat
          attr_writer :otel_conversation_id

          def otel_conversation_id
            id = @otel_attributes&.[]("gen_ai.conversation.id") || @otel_conversation_id
            id.respond_to?(:call) ? id.call : id
          end

          def with_otel_attributes(attributes)
            @otel_attributes = attributes
            self
          end

          def execute_tool(tool_call)
            attributes = {
              "gen_ai.operation.name" => "execute_tool",
              "gen_ai.tool.name" => tool_call.name,
              "gen_ai.tool.call.id" => tool_call.id,
              "gen_ai.tool.call.arguments" => tool_call.arguments.to_json,
              "gen_ai.tool.type" => "function",
              "gen_ai.tool.description" => tools[tool_call.name.to_sym]&.description
            }.compact

            tracer.in_span("execute_tool #{tool_call.name}", attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::INTERNAL) do |span|
              begin
                result = super
              rescue => e
                span.record_exception(e)
                span.status = OpenTelemetry::Trace::Status.error(e.message)
                span.set_attribute("error.type", e.class.name)
                raise
              end

              # `RubyLLM::Tool::Halt#to_s` returns `@content.to_s`, so preserve
              # `to_s` for Halt (ruby_llm 1.x only; 2.0 removed it) and
              # plain-result cases while serializing hashes.
              tool_result = result.is_a?(Hash) ? result.to_json : result.to_s
              span.set_attribute("gen_ai.tool.call.result", tool_result[0, tool_result_max_length])

              result
            end
          end

          private

          # Wraps one provider request: `complete` on 1.x, `generate` on 2.0.
          def in_chat_span(streaming:)
            provider = @model&.provider || "unknown"
            model_id = @model&.id || "unknown"

            attributes = {
              "gen_ai.operation.name" => "chat",
              "gen_ai.provider.name" => provider,
              "gen_ai.request.model" => model_id,
            }
            conversation_id = otel_conversation_id
            attributes["gen_ai.conversation.id"] = conversation_id if conversation_id
            # Per GenAI semconv: set `gen_ai.request.stream` if and only if
            # the request is streaming. Absence means non-streaming.
            attributes["gen_ai.request.stream"] = true if streaming

            tracer.in_span("chat #{model_id}", attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::CLIENT) do |span|
              begin
                result = yield
              rescue => e
                span.record_exception(e)
                span.status = OpenTelemetry::Trace::Status.error(e.message)
                span.set_attribute("error.type", e.class.name)
                raise
              end

              if @messages.last
                response = @messages.last
                adapter = Adapters.current

                response_model = adapter.response_model(response)
                span.set_attribute("gen_ai.response.model", response_model) if response_model
                adapter.usage_attributes(response).each { |key, value| span.set_attribute(key, value) }
                span.set_attribute("gen_ai.request.temperature", @temperature) if @temperature

                if capture_content?
                  system_messages = @messages.select { |m| m.role == :system }
                  input_messages = @messages[0..-2].reject { |m| m.role == :system }

                  unless system_messages.empty?
                    span.set_attribute("gen_ai.system_instructions", MessageFormatter.format_system_instructions(system_messages))
                  end

                  span.set_attribute("gen_ai.input.messages", MessageFormatter.format_input_messages(input_messages))
                  span.set_attribute("gen_ai.output.messages", MessageFormatter.format_output_messages([response]))
                end
              end

              result
            ensure
              set_custom_attributes(span)
            end
          end

          def set_custom_attributes(span)
            @otel_attributes&.each { |key, value| span.set_attribute(key, value.respond_to?(:call) ? value.call : value) }
          end

          def capture_content?
            env_value = ENV["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"]
            return env_value.to_s.strip.casecmp("true").zero? unless env_value.nil?

            RubyLLM::Instrumentation.instance.config[:capture_content]
          end

          def tool_result_max_length
            env_value = ENV["OTEL_INSTRUMENTATION_GENAI_TOOL_RESULT_MAX_LENGTH"]
            if env_value
              parsed = Integer(env_value.to_s.strip, exception: false)
              return parsed unless parsed.nil?
            end

            RubyLLM::Instrumentation.instance.config[:tool_result_max_length]
          end

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end
        end

        # 1.x: `complete` is one request and recurses, so a turn nests itself.
        module ChatComplete
          def complete(&)
            in_chat_span(streaming: block_given?) { super }
          end
        end

        # 2.0: `complete` became a loop, so the one request is `generate`,
        # which is also reachable on its own via `ask_later`.
        module ChatGenerate
          def generate(&)
            in_chat_span(streaming: block_given?) { super }
          end

          # 2.0 runs tools between `generate` calls, so without this span a
          # turn is three sibling roots, i.e. three unrelated traces. Not
          # named `chat`: that means exactly one provider request on every
          # version. Carries no usage, so nothing is counted twice, but it is
          # the trace root, so it must carry the custom attributes that
          # backends read at trace level.
          def complete(&)
            return super unless tools.any?

            model_id = @model&.id || "unknown"
            attributes = {
              "gen_ai.operation.name" => "chat_turn",
              "gen_ai.provider.name" => @model&.provider || "unknown",
              "gen_ai.request.model" => model_id
            }
            conversation_id = otel_conversation_id
            attributes["gen_ai.conversation.id"] = conversation_id if conversation_id

            tracer.in_span("chat_turn #{model_id}", attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::INTERNAL) do |span|
              super
            rescue => e
              span.record_exception(e)
              span.status = OpenTelemetry::Trace::Status.error(e.message)
              span.set_attribute("error.type", e.class.name)
              raise
            ensure
              set_custom_attributes(span)
            end
          end
        end
      end
    end
  end
end
