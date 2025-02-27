# frozen_string_literal: true

require "time"
require "active_support/json"

module ActiveSupport
  module Messages # :nodoc:
    module Metadata # :nodoc:
      singleton_class.attr_accessor :use_message_serializer_for_metadata

      ENVELOPE_SERIALIZERS = [
        ::JSON,
        ActiveSupport::JSON,
        ActiveSupport::JsonWithMarshalFallback,
        Marshal,
      ]

      private
        def serialize_with_metadata(data, **metadata)
          has_metadata = metadata.any? { |k, v| v }

          if has_metadata && !use_message_serializer_for_metadata?
            data_string = serialize_to_json_safe_string(data)
            envelope = wrap_in_metadata_envelope({ "message" => data_string }, **metadata)
            ActiveSupport::JSON.encode(envelope)
          else
            data = wrap_in_metadata_envelope({ "data" => data }, **metadata) if has_metadata
            serialize(data)
          end
        end

        def deserialize_with_metadata(message, **expected_metadata)
          if dual_serialized_metadata_envelope_json?(message)
            envelope = ActiveSupport::JSON.decode(message)
            extracted = extract_from_metadata_envelope(envelope, **expected_metadata)
            deserialize_from_json_safe_string(extracted["message"]) if extracted
          else
            deserialized = deserialize(message)
            if metadata_envelope?(deserialized)
              extracted = extract_from_metadata_envelope(deserialized, **expected_metadata)
              extracted["data"] if extracted
            else
              deserialized if expected_metadata.none? { |k, v| v }
            end
          end
        end

        def use_message_serializer_for_metadata?
          Metadata.use_message_serializer_for_metadata && Metadata::ENVELOPE_SERIALIZERS.include?(serializer)
        end

        def wrap_in_metadata_envelope(hash, expires_at: nil, expires_in: nil, purpose: nil)
          expiry = pick_expiry(expires_at, expires_in)
          hash["exp"] = expiry if expiry
          hash["pur"] = purpose.to_s if purpose
          { "_rails" => hash }
        end

        def extract_from_metadata_envelope(envelope, purpose: nil)
          hash = envelope["_rails"]
          return if hash["exp"] && Time.now.utc >= parse_expiry(hash["exp"])
          return if hash["pur"] != purpose&.to_s
          hash
        end

        def metadata_envelope?(object)
          object.is_a?(Hash) && object.key?("_rails")
        end

        def dual_serialized_metadata_envelope_json?(string)
          string.start_with?('{"_rails":{"message":')
        end

        def pick_expiry(expires_at, expires_in)
          if expires_at
            expires_at.utc.iso8601(3)
          elsif expires_in
            Time.now.utc.advance(seconds: expires_in).iso8601(3)
          end
        end

        def parse_expiry(expires_at)
          if !expires_at.is_a?(String)
            expires_at
          elsif ActiveSupport.use_standard_json_time_format
            Time.iso8601(expires_at)
          else
            Time.parse(expires_at)
          end
        end

        def serialize_to_json_safe_string(data)
          encode(serialize(data), url_safe: false)
        end

        def deserialize_from_json_safe_string(string)
          deserialize(decode(string, url_safe: false))
        end
    end
  end
end
