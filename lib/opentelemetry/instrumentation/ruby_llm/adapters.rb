# frozen_string_literal: true

module OpenTelemetry
  module Instrumentation
    module RubyLLM
      # One adapter per supported ruby_llm major, chosen at install.
      module Adapters
        class << self
          def current
            @current ||= for_version(::RubyLLM::VERSION)
          end

          # Discriminates on the major segment, not `>=`: a prerelease sorts
          # below the release it leads to, so `2.0.0.rc1 >= 2.0` is false and
          # a `>=` test would hand it the 1.x adapter.
          def for_version(version)
            ADAPTERS[Gem::Version.new(version).segments.first]
          end
        end

        module V1
          def self.chat_patch
            Patches::ChatComplete
          end

          def self.response_model(message)
            message.model_id
          end

          def self.usage_attributes(message)
            attributes = {
              "gen_ai.usage.input_tokens" => message.input_tokens,
              "gen_ai.usage.output_tokens" => message.output_tokens
            }

            # Prompt-cache token accessors were added in ruby_llm 1.9.0 (commit 869a755f).
            if message.respond_to?(:cached_tokens)
              attributes["gen_ai.usage.cache_read.input_tokens"] = message.cached_tokens
            end

            if message.respond_to?(:cache_creation_tokens)
              attributes["gen_ai.usage.cache_creation.input_tokens"] = message.cache_creation_tokens
            end

            attributes.compact
          end

          def self.resolve_model(model_id, provider:, assume_model_exists:, config:)
            ::RubyLLM::Models.resolve(
              model_id, provider: provider, assume_exists: assume_model_exists, config: config
            ).first
          end

          def self.embedding_input_tokens(result)
            result.input_tokens
          end

          def self.content_parts(message)
            content = message.content
            return [] if content.nil?

            # `RubyLLM::Content::Raw` was added in ruby_llm 1.9.0, so guard
            # the constant rather than referencing it in a `case`/`when`.
            if defined?(::RubyLLM::Content::Raw) && content.is_a?(::RubyLLM::Content::Raw)
              # Serialize the provider-specific payload to JSON so consumers
              # (e.g. Langfuse) render it as readable text rather than
              # `[object Object]`.
              [{ type: "raw", content: content.value.to_json }]
            elsif content.is_a?(::RubyLLM::Content)
              parts = []
              parts << { type: "text", content: content.text } unless content.text.nil?
              parts.concat(content.attachments.map { |a| MessageFormatter.attachment_part(a) })
            else
              [{ type: "text", content: content.to_s }]
            end
          end
        end

        module V2
          def self.chat_patch
            Patches::ChatGenerate
          end

          def self.response_model(message)
            message.model
          end

          def self.usage_attributes(message)
            tokens = message.tokens
            return {} unless tokens

            {
              "gen_ai.usage.input_tokens" => tokens.input,
              "gen_ai.usage.output_tokens" => tokens.output,
              "gen_ai.usage.cache_read.input_tokens" => tokens.cache_read,
              "gen_ai.usage.cache_creation.input_tokens" => tokens.cache_write
            }.compact
          end

          def self.resolve_model(model_id, provider:, assume_model_exists:, config:)
            ::RubyLLM::Models.resolve(
              model_id, provider: provider, assume_model_exists: assume_model_exists, config: config
            ).first
          end

          def self.embedding_input_tokens(result)
            result.tokens&.input
          end

          def self.content_parts(message)
            content = message.content
            parts = content.nil? ? [] : [{ type: "text", content: content }]
            parts.concat(message.attachments.map { |a| MessageFormatter.attachment_part(a) })
          end
        end

        # A major missing here is refused by the `compatible` gate.
        ADAPTERS = { 1 => V1, 2 => V2 }.freeze
        SUPPORTED_MAJORS = ADAPTERS.keys.freeze
      end
    end
  end
end
