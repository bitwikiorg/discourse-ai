# frozen_string_literal: true

module DiscourseAi
  module Completions
    module Endpoints
      class VeniceAi < Base
        def self.can_contact?(model_provider)
          %w[venice].include?(model_provider)
        end

        def normalize_model_params(model_params)
          # Leave values unchanged — Venice expects certain raw fields
          model_params
        end

        def default_options
          {
            model: llm_model.name,
            stream: true,
            temperature: 0.7,
            user: "discourse"
          }
        end

        def provider_id
          AiApiAuditLog::Provider::Custom
        end

        def perform_completion!(
          dialect,
          user,
          model_params = {},
          feature_name: nil,
          feature_context: nil,
          partial_tool_calls: false,
          output_thinking: false,
          &blk
        )
          @disable_native_tools = dialect.disable_native_tools?
          super
        end

        private

        def model_uri
          URI.join(llm_model.url, "/api/v1/chat/completions")
        end

        def prepare_payload(prompt, model_params, _dialect)
          messages = prompt.respond_to?(:messages) ? prompt.messages : prompt

          formatted_messages = messages.map do |m|
            {
              "role" => m[:role].to_s,
              "content" => m[:content].to_s
            }
          end

          payload = default_options.merge(model_params).merge("messages" => formatted_messages)

          payload
        end

        def prepare_request(payload)
          headers = {
            "Authorization" => "Bearer #{llm_model.api_key}",
            "Content-Type" => "application/json"
          }

          Net::HTTP::Post.new(model_uri, headers).tap do |r|
            r.body = JSON.generate(payload)
          end
        end

        def decode(response_raw)
          processor.process_message(JSON.parse(response_raw, symbolize_names: true))
        end

        def decode_chunk(chunk)
          @decoder ||= JsonStreamDecoder.new
          elements = (@decoder << chunk)
                      .map { |parsed_json| processor.process_streamed_message(parsed_json) }
                      .flatten.compact

          seen_tools = Set.new
          elements.select { |item| !item.is_a?(ToolCall) || seen_tools.add?(item) }
        end

        def decode_chunk_finish
          processor.finish
        end

        def xml_tools_enabled?
          !!@disable_native_tools
        end

        def processor
          @processor ||= OpenAiMessageProcessor.new(partial_tool_calls: partial_tool_calls)
        end
      end
    end
  end
end
