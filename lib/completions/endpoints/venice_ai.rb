# frozen_string_literal: true

module DiscourseAi
  module Completions
    module Endpoints
      class VeniceAi < Base
        def self.can_contact?(model_provider)
          %w[venice].include?(model_provider)
        end

        def normalize_model_params(model_params)
          model_params = model_params.dup

          if max_tokens = model_params.delete(:max_tokens)
            model_params[:max_completion_tokens] = max_tokens
          end

          if temp = model_params.delete(:temperature)
            model_params[:max_temp] = temp
          end

          if model_params[:stop_sequences]
            model_params[:stop] = model_params.delete(:stop_sequences)
          end

          model_params
        end

        def default_options
          {
            model: llm_model.name,
            stream: true,
            n: 1,
            user: "discourse",
            venice_parameters: {
              character_slug: "venice",
              enable_web_search: "auto",
              include_venice_system_prompt: true
            },
            stream_options: {
              include_usage: true
            },
            parallel_tool_calls: false,
            response_format: {
              type: "json_schema",
              json_schema: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  age: { type: "number" }
                },
                required: ["name", "age"]
              }
            }
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
          api_endpoint = llm_model.url
          api_endpoint += "/api/v1/chat/completions" unless api_endpoint.end_with?("/api/v1/chat/completions")
          @uri ||= URI(api_endpoint)
        end

        def prepare_payload(prompt, model_params, dialect)
          messages =
            if prompt.respond_to?(:to_openai)
              prompt.to_openai
            else
              prompt
            end

          formatted_messages = messages.map do |msg|
            {
              role: msg[:role].to_s,
              content: msg[:content].to_s
            }
          end

          payload = default_options.merge(model_params).merge(messages: formatted_messages)

          if !xml_tools_enabled? && dialect.tools.present?
            payload[:tools] = dialect.tools.map do |tool|
              {
                function: {
                  name: tool.dig(:function, :name).to_s,
                  description: tool.dig(:function, :description).to_s,
                  parameters: tool.dig(:function, :parameters) || {}
                },
                id: tool[:id] || "tool_#{SecureRandom.hex(4)}",
                type: tool[:type] || "function"
              }
            end

            if dialect.tool_choice.present?
              payload[:tool_choice] =
                if dialect.tool_choice == :none
                  "none"
                else
                  {
                    type: "function",
                    function: {
                      name: dialect.tool_choice.to_s
                    }
                  }
                end
            end
          end

          deep_compact(payload)
        end

        def prepare_request(payload)
          headers = {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{llm_model.api_key}"
          }

          request = Net::HTTP::Post.new(model_uri, headers)
          request.body = payload.to_json
          request
        end

        def decode(response_raw)
          processor.process_message(JSON.parse(response_raw, symbolize_names: true))
        end

        def decode_chunk(chunk)
          @decoder ||= JsonStreamDecoder.new
          elements =
            (@decoder << chunk)
              .map { |parsed_json| processor.process_streamed_message(parsed_json) }
              .flatten
              .compact

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

        # 🧼 Deeply remove nil values from all levels of the hash
        def deep_compact(obj)
          case obj
          when Hash
            obj.each_with_object({}) do |(k, v), h|
              compacted = deep_compact(v)
              h[k] = compacted unless compacted.nil?
            end
          when Array
            obj.map { |e| deep_compact(e) }.compact
          else
            obj
          end
        end
      end
    end
  end
end
