# frozen_string_literal: true

require "openssl"
require "base64"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/messages/codec"
require "active_support/messages/rotator"
require "active_support/message_verifier"

module ActiveSupport
  # MessageEncryptor is a simple way to encrypt values which get stored
  # somewhere you don't trust.
  #
  # The cipher text and initialization vector are base64 encoded and returned
  # to you.
  #
  # This can be used in situations similar to the MessageVerifier, but
  # where you don't want users to be able to determine the value of the payload.
  #
  #   len   = ActiveSupport::MessageEncryptor.key_len
  #   salt  = SecureRandom.random_bytes(len)
  #   key   = ActiveSupport::KeyGenerator.new('password').generate_key(salt, len) # => "\x89\xE0\x156\xAC..."
  #   crypt = ActiveSupport::MessageEncryptor.new(key)                            # => #<ActiveSupport::MessageEncryptor ...>
  #   encrypted_data = crypt.encrypt_and_sign('my secret data')                   # => "NlFBTTMwOUV5UlA1QlNEN2xkY2d6eThYWWh..."
  #   crypt.decrypt_and_verify(encrypted_data)                                    # => "my secret data"
  #
  # The +decrypt_and_verify+ method will raise an
  # <tt>ActiveSupport::MessageEncryptor::InvalidMessage</tt> exception if the data
  # provided cannot be decrypted or verified.
  #
  #   crypt.decrypt_and_verify('not encrypted data') # => ActiveSupport::MessageEncryptor::InvalidMessage
  #
  # === Confining messages to a specific purpose
  #
  # By default any message can be used throughout your app. But they can also be
  # confined to a specific +:purpose+.
  #
  #   token = crypt.encrypt_and_sign("this is the chair", purpose: :login)
  #
  # Then that same purpose must be passed when verifying to get the data back out:
  #
  #   crypt.decrypt_and_verify(token, purpose: :login)    # => "this is the chair"
  #   crypt.decrypt_and_verify(token, purpose: :shipping) # => nil
  #   crypt.decrypt_and_verify(token)                     # => nil
  #
  # Likewise, if a message has no purpose it won't be returned when verifying with
  # a specific purpose.
  #
  #   token = crypt.encrypt_and_sign("the conversation is lively")
  #   crypt.decrypt_and_verify(token, purpose: :scare_tactics) # => nil
  #   crypt.decrypt_and_verify(token)                          # => "the conversation is lively"
  #
  # === Making messages expire
  #
  # By default messages last forever and verifying one year from now will still
  # return the original value. But messages can be set to expire at a given
  # time with +:expires_in+ or +:expires_at+.
  #
  #   crypt.encrypt_and_sign(parcel, expires_in: 1.month)
  #   crypt.encrypt_and_sign(doowad, expires_at: Time.now.end_of_year)
  #
  # Then the messages can be verified and returned up to the expire time.
  # Thereafter, verifying returns +nil+.
  #
  # === Rotating keys
  #
  # MessageEncryptor also supports rotating out old configurations by falling
  # back to a stack of encryptors. Call +rotate+ to build and add an encryptor
  # so +decrypt_and_verify+ will also try the fallback.
  #
  # By default any rotated encryptors use the values of the primary
  # encryptor unless specified otherwise.
  #
  # You'd give your encryptor the new defaults:
  #
  #   crypt = ActiveSupport::MessageEncryptor.new(@secret, cipher: "aes-256-gcm")
  #
  # Then gradually rotate the old values out by adding them as fallbacks. Any message
  # generated with the old values will then work until the rotation is removed.
  #
  #   crypt.rotate old_secret            # Fallback to an old secret instead of @secret.
  #   crypt.rotate cipher: "aes-256-cbc" # Fallback to an old cipher instead of aes-256-gcm.
  #
  # Though if both the secret and the cipher was changed at the same time,
  # the above should be combined into:
  #
  #   crypt.rotate old_secret, cipher: "aes-256-cbc"
  class MessageEncryptor < Messages::Codec
    prepend Messages::Rotator::Encryptor

    cattr_accessor :use_authenticated_message_encryption, instance_accessor: false, default: false
    cattr_accessor :default_message_encryptor_serializer, instance_accessor: false, default: :marshal

    class << self
      def default_cipher # :nodoc:
        if use_authenticated_message_encryption
          "aes-256-gcm"
        else
          "aes-256-cbc"
        end
      end
    end

    module NullSerializer # :nodoc:
      def self.load(value)
        value
      end

      def self.dump(value)
        value
      end
    end

    class InvalidMessage < StandardError; end
    OpenSSLCipherError = OpenSSL::Cipher::CipherError

    AUTH_TAG_LENGTH = 16 # :nodoc:
    SEPARATOR = "--" # :nodoc:

    # Initialize a new MessageEncryptor. +secret+ must be at least as long as
    # the cipher key size. For the default 'aes-256-gcm' cipher, this is 256
    # bits. If you are using a user-entered secret, you can generate a suitable
    # key by using ActiveSupport::KeyGenerator or a similar key
    # derivation function.
    #
    # First additional parameter is used as the signature key for MessageVerifier.
    # This allows you to specify keys to encrypt and sign data.
    #
    #    ActiveSupport::MessageEncryptor.new('secret', 'signature_secret')
    #
    # Options:
    # * <tt>:cipher</tt>     - Cipher to use. Can be any cipher returned by
    #   <tt>OpenSSL::Cipher.ciphers</tt>. Default is 'aes-256-gcm'.
    # * <tt>:digest</tt> - String of digest to use for signing. Default is
    #   +SHA1+. Ignored when using an AEAD cipher like 'aes-256-gcm'.
    # * <tt>:serializer</tt> - Object serializer to use. Default is +JSON+.
    # * <tt>:url_safe</tt> - Whether to encode messages using a URL-safe
    #   encoding. Default is +false+ for backward compatibility.
    def initialize(secret, sign_secret = nil, cipher: nil, digest: nil, serializer: nil, url_safe: false)
      super(serializer: serializer || @@default_message_encryptor_serializer, url_safe: url_safe)
      @secret = secret
      @cipher = cipher || self.class.default_cipher
      @aead_mode = new_cipher.authenticated?
      @verifier = if !@aead_mode
        MessageVerifier.new(sign_secret || secret, digest: digest || "SHA1", serializer: NullSerializer, url_safe: url_safe)
      end
    end

    # Encrypt and sign a message. We need to sign the message in order to avoid
    # padding attacks. Reference: https://www.limited-entropy.com/padding-oracle-attacks/.
    #
    # ==== Options
    #
    # [+:expires_at+]
    #   The datetime at which the message expires. After this datetime,
    #   verification of the message will fail.
    #
    #     message = encryptor.encrypt_and_sign("hello", expires_at: Time.now.tomorrow)
    #     encryptor.decrypt_and_verify(message) # => "hello"
    #     # 24 hours later...
    #     encryptor.decrypt_and_verify(message) # => nil
    #
    # [+:expires_in+]
    #   The duration for which the message is valid. After this duration has
    #   elapsed, verification of the message will fail.
    #
    #     message = encryptor.encrypt_and_sign("hello", expires_in: 24.hours)
    #     encryptor.decrypt_and_verify(message) # => "hello"
    #     # 24 hours later...
    #     encryptor.decrypt_and_verify(message) # => nil
    #
    # [+:purpose+]
    #   The purpose of the message. If specified, the same purpose must be
    #   specified when verifying the message; otherwise, verification will fail.
    #   (See #decrypt_and_verify.)
    def encrypt_and_sign(value, **options)
      sign(encrypt(serialize_with_metadata(value, **options)))
    end

    # Decrypt and verify a message. We need to verify the message in order to
    # avoid padding attacks. Reference: https://www.limited-entropy.com/padding-oracle-attacks/.
    #
    # ==== Options
    #
    # [+:purpose+]
    #   The purpose that the message was generated with. If the purpose does not
    #   match, +decrypt_and_verify+ will return +nil+.
    #
    #     message = encryptor.encrypt_and_sign("hello", purpose: "greeting")
    #     encryptor.decrypt_and_verify(message, purpose: "greeting") # => "hello"
    #     encryptor.decrypt_and_verify(message)                      # => nil
    #
    #     message = encryptor.encrypt_and_sign("bye")
    #     encryptor.decrypt_and_verify(message)                      # => "bye"
    #     encryptor.decrypt_and_verify(message, purpose: "greeting") # => nil
    #
    def decrypt_and_verify(message, **options)
      deserialize_with_metadata(decrypt(verify(message)), **options)
    rescue TypeError, ArgumentError, ::JSON::ParserError
      raise InvalidMessage
    end

    # Given a cipher, returns the key length of the cipher to help generate the key of desired size
    def self.key_len(cipher = default_cipher)
      OpenSSL::Cipher.new(cipher).key_len
    end

    private
      def sign(data)
        @verifier ? @verifier.generate(data) : data
      end

      def verify(data)
        @verifier ? @verifier.verify(data) : data
      end

      def encrypt(data)
        cipher = new_cipher
        cipher.encrypt
        cipher.key = @secret

        # Rely on OpenSSL for the initialization vector
        iv = cipher.random_iv
        cipher.auth_data = "" if aead_mode?

        encrypted_data = cipher.update(data)
        encrypted_data << cipher.final

        parts = [encrypted_data, iv]
        parts << cipher.auth_tag(AUTH_TAG_LENGTH) if aead_mode?

        join_parts(parts)
      end

      def decrypt(encrypted_message)
        cipher = new_cipher
        encrypted_data, iv, auth_tag = extract_parts(encrypted_message)

        # Currently the OpenSSL bindings do not raise an error if auth_tag is
        # truncated, which would allow an attacker to easily forge it. See
        # https://github.com/ruby/openssl/issues/63
        raise InvalidMessage if aead_mode? && auth_tag.bytesize != AUTH_TAG_LENGTH

        cipher.decrypt
        cipher.key = @secret
        cipher.iv  = iv
        if aead_mode?
          cipher.auth_tag = auth_tag
          cipher.auth_data = ""
        end

        decrypted_data = cipher.update(encrypted_data)
        decrypted_data << cipher.final
      rescue OpenSSLCipherError
        raise InvalidMessage
      end

      def length_after_encode(length_before_encode)
        if @url_safe
          (4 * length_before_encode / 3.0).ceil # length without padding
        else
          4 * (length_before_encode / 3.0).ceil # length with padding
        end
      end

      def length_of_encoded_iv
        @length_of_encoded_iv ||= length_after_encode(new_cipher.iv_len)
      end

      def length_of_encoded_auth_tag
        @length_of_encoded_auth_tag ||= length_after_encode(AUTH_TAG_LENGTH)
      end

      def join_parts(parts)
        parts.map! { |part| encode(part) }.join(SEPARATOR)
      end

      def extract_part(encrypted_message, rindex, length)
        index = rindex - length

        if encrypted_message[index - SEPARATOR.length, SEPARATOR.length] == SEPARATOR
          encrypted_message[index, length]
        else
          raise InvalidMessage
        end
      end

      def extract_parts(encrypted_message)
        parts = []
        rindex = encrypted_message.length

        if aead_mode?
          parts << extract_part(encrypted_message, rindex, length_of_encoded_auth_tag)
          rindex -= SEPARATOR.length + length_of_encoded_auth_tag
        end

        parts << extract_part(encrypted_message, rindex, length_of_encoded_iv)
        rindex -= SEPARATOR.length + length_of_encoded_iv

        parts << encrypted_message[0, rindex]

        parts.reverse!.map! { |part| decode(part) }
      end

      def new_cipher
        OpenSSL::Cipher.new(@cipher)
      end

      attr_reader :aead_mode
      alias :aead_mode? :aead_mode
  end
end
