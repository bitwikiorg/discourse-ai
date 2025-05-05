# frozen_string_literal: true

module DiscourseAi
  module Completions
    module Endpoints
      class VeniceAi < Base
        def self.can_contact?(model_provider)
          %w[venice].include?(model_provider)
        end

        def normalize_model_params(model_params)
          model_params # No transformation; Venice expects exact fields
        end

        def default_options
          {} # No defaults, only send exactly what Venice expects
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
          @uri ||= URI.join(llm_model.url, "/api/v1/chat/completions")
        end

        def prepare_payload(prompt, _model_params, _dialect)
          messages = prompt.respond_to?(:messages) ? prompt.messages : prompt

          {
            frequency_penalty: 0,
            max_completion_tokens: 123,
            max_temp: 1.5,
            max_tokens: 123,
            messages: messages.map { |m| { content: m[:content].to_s, role: m[:role].to_s } },
            min_p: 0.05,
            min_temp: 0.1,
            model: llm_model.name,
            n: 1,
            presence_penalty: 0,
            repetition_penalty: 1.2,
            seed: 42,
            stop: "<string>",
            stop_token_ids: [151643, 151645],
            stream: true,
            stream_options: { include_usage: true },
            temperature: 0.7,
            top_k: 40,
            top_p: 0.9,
            user: "discourse",
            venice_parameters: {
              character_slug: "venice",
              enable_web_search: "auto",
              include_venice_system_prompt: true
            },
            
        end

        def prepare_request(payload)
          headers = {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{llm_model.api_key}"
          }

          Net::HTTP::Post.new(model_uri, headers).tap do |r|
            r.body = JSON.generate(payload) # Clean serialization, avoid Rails `.to_json`
          end
        end

        def decode(response_raw)
          processor.process_message(JSON.parse(response_raw, symbolize_names: true))
        end

        def decode_chunk(chunk)
          @decoder ||= JsonStreamDecoder.new
          elements = (@decoder << chunk).map do |parsed_json|
            processor.process_streamed_message(parsed_json)
          end.flatten.compact

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
