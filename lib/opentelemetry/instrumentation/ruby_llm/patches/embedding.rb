# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      module Patches
        module Embedding
          # Naming the keywords exhaustively would reject every caller using
          # one a later ruby_llm adds, as 2.0 did with five.
          def embed(text, model: nil, provider: nil, assume_model_exists: false, context: nil, **options)
            config = context&.config || ::RubyLLM.config
            resolved_model = model || config.default_embedding_model
            model_obj = Adapters.current.resolve_model(
              resolved_model, provider: provider, assume_model_exists: assume_model_exists, config: config
            )
            # 2.0 resolves to a nil model for operations that take none.
            model_id = model_obj&.id || "unknown"
            provider_name = model_obj&.provider || "unknown"

            attributes = {
              "gen_ai.operation.name" => "embeddings",
              "gen_ai.provider.name" => provider_name,
              "gen_ai.request.model" => model_id
            }

            tracer.in_span("embeddings #{model_id}", attributes: attributes, kind: OpenTelemetry::Trace::SpanKind::CLIENT) do |span|
              begin
                result = super
              rescue => e
                span.record_exception(e)
                span.status = OpenTelemetry::Trace::Status.error(e.message)
                span.set_attribute("error.type", e.class.name)
                raise
              end

              span.set_attribute("gen_ai.response.model", result.model) if result.model

              input_tokens = Adapters.current.embedding_input_tokens(result)
              span.set_attribute("gen_ai.usage.input_tokens", input_tokens) if input_tokens&.positive?

              if result.vectors.is_a?(Array)
                first = result.vectors.first
                vector = first.is_a?(Array) ? first : result.vectors
                span.set_attribute("gen_ai.embeddings.dimension.count", vector.length) if vector.is_a?(Array)
              end

              result
            end
          end

          private

          def tracer
            RubyLLM::Instrumentation.instance.tracer
          end
        end
      end
    end
  end
end
