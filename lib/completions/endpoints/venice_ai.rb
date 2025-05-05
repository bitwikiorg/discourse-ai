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

          # Translate OpenAI-style keys to Venice-style keys
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
          {}
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
          payload = default_options.merge(model_params).merge(messages: prompt)

          if !xml_tools_enabled?
            if dialect.tools.present?
              payload[:tools] = dialect.tools
              if dialect.tool_choice.present?
                payload[:tool_choice] = dialect.tool_choice == :none ? "none" : {
                  type: "function",
                  function: {
                    name: dialect.tool_choice,
                  },
                }
              end
            end
          end

          payload
        end

        def prepare_request(payload)
          headers = {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{llm_model.api_key}"
          }

          Net::HTTP::Post.new(model_uri, headers).tap { |r| r.body = payload.to_json }
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
      end
    end
  end
end
